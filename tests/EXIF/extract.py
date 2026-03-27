from exif import Image
import os

picture = '../images/20251211-NeoCapture_S001_Trimblemx50_000001.jpg'

def getGPSFromEXIF(picurePath):
    pictureName = os.path.basename(picurePath)

    wantedTags = ["gps_altitude", "gps_img_direction", "datetime_original"]
    pairedTags = [("gps_latitude_ref", "gps_latitude"),("gps_longitude_ref", "gps_longitude") ]

    with open(picurePath, 'rb') as picture:
        myPicture = Image(picture)
        hasExif = "Yes" if myPicture.has_exif else "No"

        print("Does the picture", pictureName,"have EXIF ? :", hasExif)
        print("-----------------------------------------------------------------")

        if not hasExif:
           return

        for pictureTag in myPicture.list_all():
            if pictureTag in wantedTags:
                print(pictureTag, ":", myPicture.get(pictureTag))

        print()

        for ref, tag in pairedTags:
            print(tag, ":", myPicture.get(ref), myPicture.get(tag))
3
    
getGPSFromEXIF(picture)